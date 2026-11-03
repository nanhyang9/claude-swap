import AppKit
import SwiftUI

// MARK: - Navigation

/// Which account an add/renew flow acts on.
enum AccountTarget: Equatable {
    /// A new account is created.
    case new
    /// An existing account's sign-in is replaced in place (same slot).
    /// `kind` is its credentialKind: "login", "setup_token", "api_key" or nil.
    case renew(number: Int, email: String, name: String, kind: String?)
}

enum AddMethod: Equatable {
    case newToken, pasteToken, currentLogin
}

enum Panel: Equatable {
    case usage
    case settings
    case chooseMethod(AccountTarget)
    case method(AccountTarget, AddMethod)

    /// Where the header's back button goes.
    var parent: Panel? {
        switch self {
        case .usage: return nil
        case .settings, .chooseMethod: return .usage
        case .method(let target, _): return .chooseMethod(target)
        }
    }
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
            // header (Back) and footer (Refresh, Settings, Quit) stay visible.
            FittingScrollView(maxHeight: Self.maxContentHeight) {
                Group {
                    switch panel {
                    case .usage:
                        usagePanel
                    case .settings:
                        SettingsPanel(done: { show(.usage) })
                    case .chooseMethod(let target):
                        MethodChooser(target: target, choose: { show(.method(target, $0)) })
                    case .method(let target, let method):
                        MethodPanel(target: target, method: method, finished: { show(.usage, keepMessages: true) })
                    }
                }
                .padding(14)
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
        // Without this the panel turns see-through once another app is
        // focused: the window's own material follows the active state.
        .background(ActiveVibrancy().ignoresSafeArea())
        .onAppear { store.refresh() }
    }

    /// Screen height minus room for the menu bar, header and footer.
    private static var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(280, screen - 150)
    }

    private func show(_ next: Panel, keepMessages: Bool = false) {
        if !keepMessages { store.clearMessages() }
        withAnimation(.easeInOut(duration: 0.15)) { panel = next }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            if let parent = panel.parent {
                Button {
                    show(parent)
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
        case .chooseMethod(.new): return "Add an account"
        case .chooseMethod(.renew(_, _, let name, _)): return "Renew \(name)"
        case .method(_, .newToken): return "Create a new token"
        case .method(_, .pasteToken): return "Paste a token or API key"
        case .method(_, .currentLogin): return "Use Claude Code's login"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if panel == .usage {
                Button {
                    show(.chooseMethod(.new))
                } label: {
                    Label("Add account", systemImage: "plus.circle")
                }
                .help("Add another Claude account")
                Button {
                    store.switchToBest()
                } label: {
                    Label("Best", systemImage: "arrow.triangle.swap")
                }
                .help("Switch to the account with the most quota left")
                .disabled(store.busyMessage != nil || store.accounts.count < 2)
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
        VStack(alignment: .leading, spacing: 10) {
            StatusMessages()
            if store.accounts.isEmpty {
                Text(store.isLoading
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
                        show(.chooseMethod(.renew(
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
    let onRemove: () -> Void

    @State private var confirmingRemove = false

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
                if let kind = account.kindLabel {
                    Pill(text: kind, color: .secondary)
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
        if confirmingRemove {
            removeConfirmation
        } else {
            HStack(spacing: 8) {
                if account.isStale {
                    Text("Last known reading")
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

/// Says, at the top of every add/renew screen, which account is affected.
struct TargetBanner: View {
    let target: AccountTarget
    /// For a new account: the label typed so far (empty = automatic name).
    var newLabel: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.activeAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.activeAccent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: heading)
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

    private var icon: String {
        if case .new = target { return "person.crop.circle.badge.plus" }
        return "arrow.triangle.2.circlepath"
    }

    private var heading: String {
        if case .new = target { return "This adds a new account" }
        return "This replaces the sign-in of"
    }

    private var name: String {
        switch target {
        case .new:
            let label = newLabel.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? "Name: set automatically" : "Name: \(label)"
        case .renew(_, _, let name, _):
            return name
        }
    }

    private var detail: String? {
        switch target {
        case .new:
            return newLabel.trimmingCharacters(in: .whitespaces).isEmpty
                ? "e.g. setup-token-3@token.local (you can type a label below)"
                : nil
        case .renew(_, let email, let name, _):
            return email == name ? nil : email
        }
    }
}

/// First step: pick how to sign the account in.
struct MethodChooser: View {
    let target: AccountTarget
    let choose: (AddMethod) -> Void

    private var isNew: Bool { target == .new }

    private var kind: String? {
        if case .renew(_, _, _, let kind) = target { return kind }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TargetBanner(target: target)
            if isNew {
                question("How do you want to sign in?")
                OptionRow(
                    icon: "terminal",
                    title: "Use Claude Code's login",
                    subtitle: "Add the account you are signed in to in Claude Code right now. Recommended: its usage is shown."
                ) { choose(.currentLogin) }
                OptionRow(
                    icon: "safari",
                    title: "Create a new token",
                    subtitle: "Sign in to any Claude account in your browser (claude setup-token)."
                ) { choose(.newToken) }
                OptionRow(
                    icon: "key.horizontal",
                    title: "Paste a token or API key",
                    subtitle: "Use a setup-token (sk-ant-oat…) or API key (sk-ant-api…) you already have."
                ) { choose(.pasteToken) }
                Note(text: "Token and API-key accounts switch like any other, but their usage can't be shown: setup-tokens are inference-only, and API keys have no plan quota.")
            } else if kind == "setup_token" {
                question("How do you want to get the new token?")
                OptionRow(
                    icon: "safari",
                    title: "Create a new token",
                    subtitle: "Sign in to this account in your browser to get a fresh token."
                ) { choose(.newToken) }
                OptionRow(
                    icon: "key.horizontal",
                    title: "Paste a token",
                    subtitle: "Use a setup-token (sk-ant-oat…) you already created for this account."
                ) { choose(.pasteToken) }
            } else if kind == "api_key" {
                question("Replace the API key")
                OptionRow(
                    icon: "key.horizontal",
                    title: "Paste a new API key",
                    subtitle: "Create one in the Anthropic Console, then paste it here."
                ) { choose(.pasteToken) }
            } else {
                question("Sign in again")
                OptionRow(
                    icon: "terminal",
                    title: "Use Claude Code's login",
                    subtitle: "In Claude Code, sign in to this account again (/login), then import it here."
                ) { choose(.currentLogin) }
                Note(text: "This account is a Claude Code login, so it is renewed by signing in again. To use a setup-token or API key instead, add it as a separate account with Add account.")
            }
        }
    }

    private func question(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.top, 2)
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

struct OptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.activeAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Second step: the one method chosen, with only the fields it needs.
struct MethodPanel: View {
    @EnvironmentObject private var store: UsageStore
    let target: AccountTarget
    let method: AddMethod
    let finished: () -> Void

    @State private var token = ""
    @State private var email = ""
    @State private var alias = ""

    private var isNew: Bool { target == .new }

    /// The slot being renewed, if any.
    private var renewNumber: Int? {
        if case .renew(let number, _, _, _) = target { return number }
        return nil
    }

    /// The email the command acts on: the renewed account's, or the label.
    private var emailValue: String? {
        if case .renew(_, let email, _, _) = target { return email }
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? nil : e
    }

    private var aliasValue: String? {
        guard isNew else { return nil }
        let a = alias.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? nil : a
    }

    private var labelPreview: String {
        let a = alias.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces)
        switch (a.isEmpty, e.isEmpty) {
        case (false, false): return "\(a) (\(e))"
        case (false, true): return a
        case (true, false): return e
        case (true, true): return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TargetBanner(target: target, newLabel: method == .currentLogin ? "" : labelPreview)
            StatusMessages()
            switch method {
            case .newToken: newTokenBody
            case .pasteToken: pasteTokenBody
            case .currentLogin: currentLoginBody
            }
        }
    }

    // Label fields, for a new account made from a token (tokens carry no email).
    @ViewBuilder
    private var labelFields: some View {
        if isNew {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Name this account (optional)")
                TextField("Email, e.g. me@example.com", text: $email)
                TextField("Short alias, e.g. work", text: $alias)
            }
            .textFieldStyle(.roundedBorder)
            .card()
        }
    }

    private var newTokenBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelFields
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "What happens")
                Step(number: 1, text: "A Terminal window opens and runs claude setup-token.")
                Step(number: 2, text: isNew
                     ? "Your browser opens. Sign in with the Claude account you want to add."
                     : "Your browser opens. Sign in as \(renewName).")
                Step(number: 3, text: "Copy the code the browser shows and paste it into Terminal.")
                Step(number: 4, text: isNew
                     ? "The account appears in the list here."
                     : "This account's token is replaced.")
            }
            .card()
            HStack {
                Spacer()
                Button {
                    store.createTokenInTerminal(
                        email: emailValue, alias: aliasValue, replacing: renewNumber
                    )
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var pasteTokenBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelFields
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Token or API key")
                SecureField("sk-ant-oat01-…  or  sk-ant-api…", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text(verbatim: "Stored in your Keychain by claude-swap. Never shown again here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .card()
            HStack {
                Spacer()
                Button(isNew ? "Add account" : "Replace token") {
                    let onDone: (Bool) -> Void = { ok in
                        if ok {
                            token = ""
                            finished()
                        }
                    }
                    if let number = renewNumber {
                        store.replaceToken(token, account: number, name: renewDisplayName, completion: onDone)
                    } else {
                        store.addToken(token, email: emailValue, alias: aliasValue, completion: onDone)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || store.busyMessage != nil)
            }
        }
    }

    private var currentLoginBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "What happens")
                Step(number: 1, text: isNew
                     ? "Make sure Claude Code is signed in to the account you want to add (run /login in Claude Code if not)."
                     : "In Claude Code, sign in as \(renewName) (run /login).")
                Step(number: 2, text: "Click Import. Claude Swap saves that login as an account; an account it already has is updated instead.")
            }
            .card()
            HStack {
                Spacer()
                Button("Import") {
                    store.addCurrentLogin { ok in if ok { finished() } }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.busyMessage != nil)
            }
        }
    }

    private var renewName: String {
        if case .renew(_, let email, _, _) = target { return email }
        return ""
    }

    private var renewDisplayName: String {
        if case .renew(_, _, let name, _) = target { return name }
        return ""
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

/// The panel's material, pinned to its active look so it does not turn
/// see-through when another app takes focus.
struct ActiveVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }
}
