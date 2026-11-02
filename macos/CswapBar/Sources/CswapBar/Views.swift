import AppKit
import SwiftUI

// MARK: - Popover

enum Panel: Equatable {
    case usage
    case settings
    case addAccount(email: String?)
}

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
            Group {
                switch panel {
                case .usage:
                    usagePanel
                case .settings:
                    SettingsPanel(done: { show(.usage) })
                case .addAccount(let email):
                    AddAccountPanel(renewEmail: email, done: { show(.usage) })
                }
            }
            .padding(12)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { store.refresh() }
    }

    private func show(_ next: Panel) {
        store.clearMessages()
        withAnimation(.easeInOut(duration: 0.15)) { panel = next }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.activeAccent)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let updated = store.lastUpdated, panel == .usage {
                (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch panel {
        case .usage: return "Claude Swap"
        case .settings: return "Settings"
        case .addAccount(let email): return email == nil ? "Add account" : "Renew account"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if panel == .usage {
                Button {
                    show(.addAccount(email: nil))
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .help("Add an account (setup-token, API key, or current login)")
                Button {
                    store.switchToBest()
                } label: {
                    Label("Best", systemImage: "arrow.triangle.swap")
                }
                .help("Switch to the account with the most quota left")
                .disabled(store.busyMessage != nil || store.accounts.count < 2)
            } else {
                Button {
                    show(.usage)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            Spacer()
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
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    // MARK: Usage panel

    private var usagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusMessages()
            if store.accounts.isEmpty {
                Text(store.isLoading
                     ? "Loading…"
                     : "No accounts yet. Click Add to add one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else if store.accounts.count > 4 {
                ScrollView { cards }
                    .frame(height: 400)
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
                    onRenew: { show(.addAccount(email: account.email)) }
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
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(UsageLevel.critical.color)
        }
        if let notice = store.noticeMessage {
            Label {
                Text(notice).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.success)
        }
        if let busy = store.busyMessage {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(account.number)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14)
                Text(account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.active {
                    Pill(text: "ACTIVE", color: Theme.activeAccent)
                }
                if account.isDisabled {
                    Pill(text: "DISABLED", color: .secondary)
                }
                Spacer(minLength: 4)
                if !expanded, let pct = account.tightestPct {
                    Text("\(Int(pct.rounded()))%")
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
            Text(account.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if account.isStale {
                Text("Last known reading")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Renew…", action: onRenew)
                .controlSize(.small)
                .help("Replace this account's token or login")
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
            Text(label)
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
        Text(text)
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

struct UsageBar: View {
    let label: String
    let pct: Double
    let reset: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
                BarTrack(pct: pct)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(UsageLevel(pct).color)
                    .frame(width: 42, alignment: .trailing)
            }
            if let reset, reset > Date() {
                (Text("Resets in ") + Text(reset, style: .relative))
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
                Text("ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = usage?.plan {
                    Pill(text: plan.uppercased(), color: Theme.activeAccent)
                }
                Spacer()
                if let email = usage?.email {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let usage {
                if usage.limits.isEmpty {
                    Text("No rate limits reported for this plan.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(usage.limits) { limit in
                    if usage.limits.count > 1 {
                        Text(limit.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(limit.windows) { w in
                        UsageBar(label: w.label, pct: w.usedPercent, reset: w.resetDate)
                    }
                    if limit.limitReached == true {
                        Text("Limit reached")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UsageLevel.critical.color)
                    }
                }
                if let credits = usage.credits {
                    if credits.unlimited == true {
                        Text("Credits: unlimited").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if let balance = credits.balance, !balance.isEmpty {
                        Text("Credits: \(balance)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// MARK: - Add / renew account

struct AddAccountPanel: View {
    @EnvironmentObject private var store: UsageStore
    /// Set when renewing an existing account: its token is replaced in place.
    let renewEmail: String?
    let done: () -> Void

    @State private var token = ""
    @State private var email = ""
    @State private var alias = ""

    private var emailValue: String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? nil : e
    }

    private var aliasValue: String? {
        let a = alias.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? nil : a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusMessages()

            if let renewEmail {
                Text("Renewing \(renewEmail). Either option below replaces its token in place.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Label (optional)")
                    TextField("Email, e.g. me@example.com", text: $email)
                    TextField("Short alias, e.g. work", text: $alias)
                    Text("Setup-tokens carry no email; without a label the account is named setup-token-N@token.local.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textFieldStyle(.roundedBorder)
                .card()
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Create a new token")
                Text("Opens Terminal and runs `claude setup-token`: sign in in the browser, paste the code back, and the account is added automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button {
                        store.createTokenInTerminal(email: renewEmail ?? emailValue, alias: aliasValue)
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Use an existing token or API key")
                SecureField("sk-ant-oat01-…  or  sk-ant-api…", text: $token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Add token") {
                        store.addToken(token, email: renewEmail ?? emailValue, alias: aliasValue) { ok in
                            if ok {
                                token = ""
                                done()
                            }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || store.busyMessage != nil)
                }
            }
            .card()

            if renewEmail == nil {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Add the current Claude Code login")
                    Text("Backs up the account Claude Code is logged in with right now (`/login`).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Add current login") {
                            store.addCurrentLogin { ok in if ok { done() } }
                        }
                        .disabled(store.busyMessage != nil)
                    }
                }
                .card()
            }
        }
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
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
                Text("Using: \(store.cswapDescription.isEmpty ? "…" : store.cswapDescription)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Use a different cswap (empty = the one bundled in this app):")
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
