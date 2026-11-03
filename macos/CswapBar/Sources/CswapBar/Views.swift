import AppKit
import SwiftUI

// MARK: - Navigation

/// Which account a sign-in flow acts on.
enum AccountTarget: Equatable {
    /// A new account is added.
    case new
    /// An existing account is signed in again (same slot when it is a login).
    case renew(number: Int, email: String, name: String, kind: String?)
}

enum Panel: Equatable {
    case usage
    case settings
    case account(AccountTarget)
}

// MARK: - Popover

struct ContentView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var expandedOverride: [Int: Bool] = [:]
    @State private var panel: Panel = .usage

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            // The middle scrolls once it would outgrow the screen, so the
            // header (with Refresh, Settings, Quit) always stays visible.
            FittingScrollView(maxHeight: Self.maxContentHeight) {
                Group {
                    switch panel {
                    case .usage:
                        usagePanel
                    case .settings:
                        SettingsPanel(done: { show(.usage) })
                    case .account(let target):
                        AccountPanel(target: target, finished: { show(.usage, keepMessages: true) })
                    }
                }
                .padding(14)
            }
            if panel == .usage {
                Divider()
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .frame(width: 380)
        .onChange(of: store.openCount) { _ in
            // Every time the popover opens, start from the usage overview.
            panel = .usage
        }
    }

    private func show(_ next: Panel, keepMessages: Bool = false) {
        if !keepMessages { store.clearMessages() }
        withAnimation(.easeInOut(duration: 0.15)) { panel = next }
    }

    /// Screen height minus room for the menu bar, header and footer.
    private static var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(280, screen - 170)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            if panel != .usage {
                Button {
                    show(.usage)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Back")
                .keyboardShortcut(.cancelAction)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.activeAccent)
            }
            Text(verbatim: title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let updated = store.lastUpdated, panel == .usage {
                (Text(updated, style: .relative) + Text(" ago"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                Button {
                    store.refresh(forceChatGPT: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh (Claude usage is still paced by cswap)")
                Button {
                    show(panel == .settings ? .usage : .settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Claude Swap")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.leading, 4)
        }
    }

    private var title: String {
        switch panel {
        case .usage: return "Claude Swap"
        case .settings: return "Settings"
        case .account(.new): return "Add an account"
        case .account(.renew(_, _, let name, _)): return "Sign in again: \(name)"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                show(.account(.new))
            } label: {
                Label("Add account", systemImage: "plus.circle")
            }
            .help("Sign in to another Claude account and add it")
            Spacer()
            Button {
                store.switchToBest()
            } label: {
                Label("Switch to best", systemImage: "arrow.triangle.swap")
            }
            .help("Switch to the account with the most quota left")
            .disabled(store.busyMessage != nil || store.accounts.count < 2)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    // MARK: Usage panel

    private var usagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusMessages()
            if store.accounts.isEmpty {
                Text(verbatim: store.isLoading
                     ? "Loading…"
                     : "No accounts yet. Click Add account to add one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                cards
            }
            if store.showChatGPT {
                ChatGPTCard(usage: store.chatgpt, error: store.chatgptError)
            }
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(store.accounts) { account in
                AccountCard(
                    account: account,
                    expanded: binding(for: account),
                    actionsDisabled: store.busyMessage != nil,
                    onSwitch: { store.switchTo(account) },
                    onRenew: {
                        show(.account(.renew(
                            number: account.number,
                            email: account.email,
                            name: account.displayName,
                            kind: account.credentialKind
                        )))
                    },
                    onRemove: { store.removeAccount(account) }
                )
            }
        }
    }

    /// The active account starts expanded, the others collapsed; a click flips it.
    private func binding(for account: Account) -> Binding<Bool> {
        Binding(
            get: { expandedOverride[account.number] ?? account.active },
            set: { expandedOverride[account.number] = $0 }
        )
    }
}

// MARK: - Messages

struct StatusMessages: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        if let message = store.errorMessage {
            Label {
                Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(UsageLevel.critical.color)
        }
        if let notice = store.noticeMessage {
            Label {
                Text(verbatim: notice).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.success)
        }
        if let busy = store.busyMessage {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: busy).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Account card

struct AccountCard: View {
    let account: Account
    @Binding var expanded: Bool
    let actionsDisabled: Bool
    let onSwitch: () -> Void
    let onRenew: () -> Void
    let onRemove: () -> Void

    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: "\(account.number)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14)
                Text(verbatim: account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.active {
                    Pill(text: "ACTIVE", color: Theme.activeAccent)
                }
                if let kind = account.kindLabel {
                    Pill(text: kind, color: .secondary)
                }
                if account.isDisabled {
                    Pill(text: "DISABLED", color: .secondary)
                }
                Spacer(minLength: 4)
                if !expanded, let pct = account.tightestPct {
                    Text(verbatim: "\(Int(pct.rounded()))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(UsageLevel(pct).color)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let usage = account.shownUsage {
                CompactBars(usage: usage)
            }
        }
        .card(highlighted: account.active)
    }

    @ViewBuilder
    private var details: some View {
        if let usage = account.shownUsage {
            if let w = usage.fiveHour {
                UsageBar(label: "5h", pct: w.pct, reset: w.resetDate)
            }
            if let w = usage.sevenDay {
                UsageBar(label: "7d", pct: w.pct, reset: w.resetDate)
            }
            ForEach(usage.scoped ?? [], id: \.self) { w in
                UsageBar(label: w.name ?? "model", pct: w.pct, reset: w.resetDate)
            }
        }
        if !account.statusText.isEmpty {
            Text(verbatim: account.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if confirmingRemove {
            removeConfirmation
        } else {
            HStack(spacing: 8) {
                if account.isStale {
                    Text(verbatim: "Last known reading")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    confirmingRemove = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Remove this account from Claude Swap")
                .disabled(actionsDisabled)
                Button("Sign in again…", action: onRenew)
                    .controlSize(.small)
                    .help("Sign in to this account again (for example when its login expired)")
                    .disabled(actionsDisabled)
                if !account.active {
                    Button("Switch", action: onSwitch)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(actionsDisabled)
                }
            }
        }
    }

    private var removeConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Remove account \(account.number) (\(account.displayName)) from Claude Swap?")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: account.active
                 ? "It is the active account: Claude Code stays signed in to it, but Claude Swap stops managing it."
                 : "Its saved sign-in is deleted from Claude Swap. Claude Code itself is not changed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmingRemove = false }
                    .controlSize(.small)
                Button("Remove") {
                    confirmingRemove = false
                    onRemove()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(UsageLevel.critical.color)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(UsageLevel.critical.color.opacity(0.08))
        )
    }
}

/// Two thin bars (5h, 7d) for a collapsed card.
struct CompactBars: View {
    let usage: AccountUsage

    var body: some View {
        HStack(spacing: 8) {
            if let w = usage.fiveHour { MiniBar(label: "5h", pct: w.pct) }
            if let w = usage.sevenDay { MiniBar(label: "7d", pct: w.pct) }
        }
    }
}

struct MiniBar: View {
    let label: String
    let pct: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            BarTrack(pct: pct, height: 5)
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Usage bar

/// A rounded bar drawn by hand: the system ProgressView ignores custom
/// colours on macOS, which made every bar the same grey.
struct BarTrack: View {
    let pct: Double
    var height: CGFloat = 8

    var body: some View {
        let fraction = CGFloat(min(max(pct, 0), 100) / 100)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(UsageLevel(pct).color)
                    .frame(width: fraction > 0 ? max(geo.size.width * fraction, height) : 0)
            }
        }
        .frame(height: height)
    }
}

/// Absolute reset times in one fixed-width shape ("11/09 (Mon) 14:32").
enum ResetFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd (EEE) HH:mm"
        return f
    }()

    static func absolute(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

struct UsageBar: View {
    let label: String
    let pct: Double
    let reset: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
                BarTrack(pct: pct)
                Text(verbatim: "\(Int(pct.rounded()))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(UsageLevel(pct).color)
                    .frame(width: 42, alignment: .trailing)
            }
            if let reset, reset > Date() {
                // The absolute time is pinned to the right edge, so it stays
                // in place however long the relative countdown is.
                HStack(spacing: 8) {
                    (Text("Resets in ") + Text(reset, style: .relative))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: ResetFormat.absolute(reset))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 60)
            }
        }
    }
}

// MARK: - ChatGPT

struct ChatGPTCard: View {
    let usage: ChatGPTUsage?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: "ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = usage?.plan {
                    Pill(text: plan.uppercased(), color: Theme.activeAccent)
                }
                Spacer()
                if let email = usage?.email {
                    Text(verbatim: email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let usage {
                if usage.limits.isEmpty {
                    Text(verbatim: "No rate limits reported for this plan.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(usage.limits) { limit in
                    if usage.limits.count > 1 {
                        Text(verbatim: limit.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(limit.windows) { w in
                        UsageBar(label: w.label, pct: w.usedPercent, reset: w.resetDate)
                    }
                    if limit.limitReached == true {
                        Text(verbatim: "Limit reached")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UsageLevel.critical.color)
                    }
                }
                if let credits = usage.credits {
                    if credits.unlimited == true {
                        Text(verbatim: "Credits: unlimited").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if let balance = credits.balance, !balance.isEmpty {
                        Text(verbatim: "Credits: \(balance)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: "Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// MARK: - Add / sign in again

/// Says, at the top of the sign-in screen, which account is affected.
struct TargetBanner: View {
    let target: AccountTarget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isNew ? "person.crop.circle.badge.plus" : "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.activeAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.activeAccent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: isNew ? "This adds a new account" : "This signs in again")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var isNew: Bool { target == .new }

    private var name: String {
        switch target {
        case .new: return "Whichever account you sign in with"
        case .renew(_, _, let name, _): return name
        }
    }

    private var detail: String? {
        switch target {
        case .new: return "Its email is read from the login."
        case .renew(_, let email, let name, _): return email == name ? nil : email
        }
    }
}

/// One screen for adding an account or signing one in again: Terminal runs
/// `claude auth login`, then the login is imported. Only full logins can
/// show usage, so tokens and API keys are not offered here (they remain
/// available from the command line: `cswap setup-token`).
struct AccountPanel: View {
    @EnvironmentObject private var store: UsageStore
    let target: AccountTarget
    let finished: () -> Void

    private var isNew: Bool { target == .new }

    private var renewEmail: String? {
        if case .renew(_, let email, _, _) = target, !email.hasSuffix("@token.local") {
            return email
        }
        return nil
    }

    private var renewKind: String? {
        if case .renew(_, _, _, let kind) = target { return kind }
        return nil
    }

    private var renewName: String {
        if case .renew(_, _, let name, _) = target { return name }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TargetBanner(target: target)
            StatusMessages()

            if renewKind == "setup_token" || renewKind == "api_key" {
                Note(text: "This is a token account, so its usage can't be shown. Signing in creates a full login for it (usage included); afterwards remove the token entry with its trash button.")
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "What happens")
                Step(number: 1, text: "A Terminal window opens and runs claude auth login.")
                Step(number: 2, text: isNew
                     ? "Your browser opens. Sign in with the Claude account you want to add."
                     : "Your browser opens. Sign in as \(renewEmail ?? renewName).")
                Step(number: 3, text: isNew
                     ? "The account is added automatically and appears in the list."
                     : "The account's saved sign-in is updated automatically.")
                Text(verbatim: "Claude Code stays signed in to that account afterwards; switch back to any other account from the list.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .card()

            HStack {
                Spacer()
                Button {
                    store.signInInTerminal(email: renewEmail)
                } label: {
                    Label("Sign in with Terminal", systemImage: "terminal")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: isNew
                     ? "Already signed in to it in Claude Code?"
                     : "Already signed in as this account in Claude Code?")
                    .font(.system(size: 12, weight: .semibold))
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Import that login without opening Terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Import current login") {
                        store.addCurrentLogin { ok in if ok { finished() } }
                    }
                    .controlSize(.small)
                    .disabled(store.busyMessage != nil)
                }
            }
        }
    }
}

struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.activeAccent))
            Text(verbatim: text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Note: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(verbatim: text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @EnvironmentObject private var store: UsageStore
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusMessages()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show ChatGPT (Codex) usage", isOn: $store.showChatGPT)
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
            }
            .card()
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "claude-swap")
                Text(verbatim: "Using: \(store.cswapDescription.isEmpty ? "…" : store.cswapDescription)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: "Use a different cswap (empty = the one bundled in this app):")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("~/.local/bin/cswap", text: $store.cswapPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            .card()
            HStack {
                Spacer()
                Button("Done") {
                    done()
                    store.refresh(forceChatGPT: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { store.describeCswap() }
    }
}

// MARK: - Layout helpers

/// A scroll view exactly as tall as its content, up to `maxHeight`.
struct FittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
