import AppKit
import SwiftUI

// MARK: - Popover

struct ContentView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var expandedOverride: [Int: Bool] = [:]
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if showingSettings {
                SettingsPanel(done: { showingSettings = false })
            } else {
                if let message = store.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let busy = store.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                }
                accountList
                if store.showChatGPT {
                    Divider()
                    ChatGPTSection(usage: store.chatgpt, error: store.chatgptError)
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack {
            Text(showingSettings ? "Settings" : "Claude usage")
                .font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if store.accounts.isEmpty {
            Text(store.isLoading ? "Loading…" : "No managed accounts. Add one with `cswap add` or `cswap setup-token`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.accounts.count > 4 {
            ScrollView {
                cards
            }
            .frame(height: 420)
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(store.accounts) { account in
                AccountCard(
                    account: account,
                    expanded: binding(for: account),
                    switchDisabled: store.busyMessage != nil,
                    onSwitch: { store.switchTo(account) }
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

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.switchToBest()
            } label: {
                Label("Switch to best", systemImage: "arrow.triangle.swap")
            }
            .disabled(store.busyMessage != nil || store.accounts.count < 2)

            Spacer()

            if let updated = store.lastUpdated {
                (Text(updated, style: .relative) + Text(" ago"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                store.refresh(forceChatGPT: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (Claude usage is still paced by cswap)")
            Button {
                showingSettings.toggle()
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
    }
}

// MARK: - Account card

struct AccountCard: View {
    let account: Account
    @Binding var expanded: Bool
    let switchDisabled: Bool
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Text("\(account.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(account.displayName)
                    .font(.system(size: 13, weight: account.active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.isDisabled {
                    Text("disabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !expanded, let pct = account.tightestPct {
                    Text("\(Int(pct.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(UsageBar.color(for: pct))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
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
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(account.active ? 0.08 : 0.04))
        )
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if account.isStale {
                Text("last known reading")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !account.active {
                Button("Switch to this account", action: onSwitch)
                    .controlSize(.small)
                    .disabled(switchDisabled)
            }
        }
    }
}

// MARK: - Usage bar

struct UsageBar: View {
    let label: String
    let pct: Double
    let reset: Date?

    static func color(for pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
                ProgressView(value: min(max(pct, 0), 100), total: 100)
                    .tint(Self.color(for: pct))
                Text("\(Int(pct.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            if let reset, reset > Date() {
                (Text("resets in ") + Text(reset, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 60)
            }
        }
    }
}

// MARK: - ChatGPT

struct ChatGPTSection: View {
    let usage: ChatGPTUsage?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ChatGPT")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = usage?.plan {
                    Text(plan.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if let email = usage?.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let usage {
                if usage.limits.isEmpty {
                    Text("No rate limits reported for this plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(usage.limits) { limit in
                    if usage.limits.count > 1 {
                        Text(limit.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(limit.windows) { w in
                        UsageBar(label: w.label, pct: w.usedPercent, reset: w.resetDate)
                    }
                    if limit.limitReached == true {
                        Text("Limit reached")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if let credits = usage.credits {
                    if credits.unlimited == true {
                        Text("Credits: unlimited").font(.caption2).foregroundStyle(.secondary)
                    } else if let balance = credits.balance, !balance.isEmpty {
                        Text("Credits: \(balance)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @EnvironmentObject private var store: UsageStore
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show ChatGPT (Codex) usage", isOn: $store.showChatGPT)
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            VStack(alignment: .leading, spacing: 4) {
                Text("Using: \(store.cswapDescription.isEmpty ? "…" : store.cswapDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use a different cswap (empty = the one bundled in this app)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("~/.local/bin/cswap", text: $store.cswapPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            if let message = store.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
