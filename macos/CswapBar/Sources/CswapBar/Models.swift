import Foundation

// Decodable mirrors of `cswap list --json` (schema v1) and `cswap chatgpt --json`.
// Every field the app does not strictly need is optional, so additive schema
// changes on the Python side never break decoding.

struct UsageWindow: Decodable, Hashable {
    let pct: Double
    let resetsAt: String?
    let name: String?  // per-model ("scoped") windows only

    var resetDate: Date? { resetsAt.flatMap(ISODate.parse) }
}

struct AccountUsage: Decodable, Hashable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let scoped: [UsageWindow]?
}

struct Account: Decodable, Identifiable, Hashable {
    let number: Int
    let email: String
    let alias: String?
    let active: Bool
    let disabled: Bool?
    let usageStatus: String
    let usage: AccountUsage?
    let lastGoodUsage: AccountUsage?
    /// "login" | "setup_token" | "api_key" (absent on older cswap versions).
    let credentialKind: String?
    /// Last fetch failure by kind (e.g. "http-403"), when usage is unavailable.
    let usageError: String?

    var id: Int { number }

    var isLogin: Bool { credentialKind == "login" }
    var isSetupToken: Bool { credentialKind == "setup_token" }
    var isAPIKey: Bool { credentialKind == "api_key" || usageStatus == "api_key" }

    /// Short label for the kind of sign-in, shown on the card.
    var kindLabel: String? {
        switch credentialKind {
        case "setup_token": return "TOKEN"
        case "api_key": return "API KEY"
        default: return nil
        }
    }

    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return email
    }

    /// Decision-grade usage when present, else the last known reading.
    var shownUsage: AccountUsage? { usage ?? lastGoodUsage }

    /// True when only a last known (older) reading is available.
    var isStale: Bool { usage == nil && lastGoodUsage != nil }

    var isDisabled: Bool { disabled ?? false }

    /// The fullest of the 5h / 7d windows, used for the compact summary.
    var tightestPct: Double? {
        guard let u = shownUsage else { return nil }
        let values = [u.fiveHour?.pct, u.sevenDay?.pct].compactMap { $0 }
        return values.max()
    }

    var statusText: String {
        switch usageStatus {
        case "ok": return ""
        case "token_expired": return "Token expired — Claude Code refreshes it on next use"
        case "api_key": return "API key (no subscription quota)"
        case "keychain_unavailable": return "Keychain unavailable"
        case "relogin_required": return "Re-login needed (cswap add --slot \(number))"
        case "foreign_credential": return "Login belongs to another account"
        case "no_credentials": return "No stored credentials"
        default:
            if isSetupToken {
                // Claude Code itself reads usage only for tokens with the
                // user:profile scope; setup-tokens are inference-only.
                return "Usage isn't available for setup-token accounts (the token is inference-only). Switching and using it in Claude Code still work."
            }
            if let usageError { return "Usage unavailable (\(usageError))" }
            return "Usage unavailable"
        }
    }
}

struct AccountList: Decodable {
    let activeAccountNumber: Int?
    let accounts: [Account]
}

struct CLIErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let type: String?
        let message: String
    }
    let error: Detail
}

struct ChatGPTWindow: Decodable, Hashable, Identifiable {
    let label: String
    let usedPercent: Double
    let windowSeconds: Int?
    let resetsAt: String?

    var id: String { label }
    var resetDate: Date? { resetsAt.flatMap(ISODate.parse) }
}

struct ChatGPTLimit: Decodable, Hashable, Identifiable {
    let name: String
    let allowed: Bool?
    let limitReached: Bool?
    let windows: [ChatGPTWindow]

    var id: String { name }
}

struct ChatGPTCredits: Decodable, Hashable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct ChatGPTUsage: Decodable, Hashable {
    let email: String?
    let plan: String?
    let limits: [ChatGPTLimit]
    let credits: ChatGPTCredits?
}

enum ISODate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses "2026-06-22T23:29:59Z", "...+00:00" and fractional-second
    /// variants (Python may emit microseconds, which the formatter rejects).
    static func parse(_ text: String) -> Date? {
        let cleaned = text.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return formatter.date(from: cleaned)
    }
}
