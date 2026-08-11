import Foundation

/// The signed-in Codex account and its remaining usage, read from the
/// app-server (`account/read` + `account/rateLimits/read`; shapes verified
/// by live probe, see the 2026-08-12 status-window spec). Parsing is
/// resilient the same way `CodexModels.list` is: missing fields degrade to
/// nil/empty, they never throw.
public struct CodexAccountStatus: Equatable, Sendable {
    public struct Account: Equatable, Sendable {
        public let email: String?
        public let planType: String?

        public init(email: String?, planType: String?) {
            self.email = email
            self.planType = planType
        }
    }

    /// One rate-limit window (`primary` of one entry in
    /// `rateLimitsByLimitId`): the main "codex" limit or a per-model one.
    public struct RateLimitWindow: Equatable, Sendable, Identifiable {
        public let id: String
        public let displayName: String
        public let usedPercent: Double
        public let windowDurationMins: Int?
        public let resetsAt: Date?

        public init(
            id: String, displayName: String, usedPercent: Double,
            windowDurationMins: Int?, resetsAt: Date?
        ) {
            self.id = id
            self.displayName = displayName
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.resetsAt = resetsAt
        }

        /// "weekly" / "5-hour" style label for the window length.
        public var windowLabel: String? {
            guard let mins = windowDurationMins else { return nil }
            if mins == 10080 { return "weekly" }
            return "\(mins / 60)-hour"
        }
    }

    public let account: Account?
    public let limits: [RateLimitWindow]
    public let resetCreditsAvailable: Int

    public init(account: Account?, limits: [RateLimitWindow], resetCreditsAvailable: Int) {
        self.account = account
        self.limits = limits
        self.resetCreditsAvailable = resetCreditsAvailable
    }

    /// Both requests over the shared app-server client.
    public static func fetch(client: AppServerClient) async throws -> CodexAccountStatus {
        let accountData = try await client.request(method: "account/read", params: [:])
        let limitsData = try await client.request(method: "account/rateLimits/read", params: [:])
        let parsed = parseRateLimits(limitsData)
        return CodexAccountStatus(
            account: parseAccount(accountData),
            limits: parsed.limits,
            resetCreditsAvailable: parsed.resetCreditsAvailable)
    }

    static func parseAccount(_ data: Data) -> Account? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let account = root?["account"] as? [String: Any] else { return nil }
        return Account(
            email: account["email"] as? String,
            planType: account["planType"] as? String)
    }

    static func parseRateLimits(
        _ data: Data
    ) -> (limits: [RateLimitWindow], resetCreditsAvailable: Int) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ([], 0) }
        // The by-id map carries every limit (main + per-model); the bare
        // `rateLimits` object is the main limit only, kept as fallback.
        let entries: [[String: Any]]
        if let byId = root["rateLimitsByLimitId"] as? [String: [String: Any]] {
            entries = Array(byId.values)
        } else if let single = root["rateLimits"] as? [String: Any] {
            entries = [single]
        } else {
            entries = []
        }
        let limits = entries.compactMap(window(from:))
            // The main "codex" limit leads; per-model limits follow by name.
            .sorted { a, b in
                if (a.id == "codex") != (b.id == "codex") { return a.id == "codex" }
                return a.displayName < b.displayName
            }
        let credits = root["rateLimitResetCredits"] as? [String: Any]
        return (limits, credits?["availableCount"] as? Int ?? 0)
    }

    private static func window(from entry: [String: Any]) -> RateLimitWindow? {
        guard let id = entry["limitId"] as? String,
            let primary = entry["primary"] as? [String: Any],
            let usedPercent = (primary["usedPercent"] as? NSNumber)?.doubleValue
        else { return nil }
        let resetsAt = (primary["resetsAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitWindow(
            id: id,
            displayName: entry["limitName"] as? String ?? (id == "codex" ? "Codex" : id),
            usedPercent: usedPercent,
            windowDurationMins: (primary["windowDurationMins"] as? NSNumber)?.intValue,
            resetsAt: resetsAt)
    }
}
