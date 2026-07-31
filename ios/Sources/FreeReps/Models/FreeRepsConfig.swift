import Foundation

enum FreeRepsConfigError: LocalizedError, Equatable {
    case invalidEndpoint
    case insecureEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter a valid absolute HTTPS endpoint URL."
        case .insecureEndpoint:
            return "The SyncHealth receiver must use HTTPS."
        }
    }
}

struct FreeRepsConfig: Codable, Equatable {
    var endpointURL: String
    /// Max months of HealthKit history to backfill. nil = all data (back to 2000).
    /// Legacy: `backfillYears` is decoded and converted to months for backward compatibility.
    var backfillMonths: Int? = 24
    var rollingWindowDays: Int = 7

    /// Backward-compatible computed property. Setting this updates backfillMonths.
    var backfillYears: Int? {
        get { backfillMonths.map { $0 / 12 } }
        set { backfillMonths = newValue.map { $0 * 12 } }
    }

    init(
        endpointURL: String,
        backfillMonths: Int? = 24,
        rollingWindowDays: Int = 7
    ) {
        self.endpointURL = endpointURL
        self.backfillMonths = backfillMonths
        self.rollingWindowDays = max(1, rollingWindowDays)
    }

    static let `default` = FreeRepsConfig(
        endpointURL: "https://your-host.example/health",
        backfillMonths: 24,
        rollingWindowDays: 7
    )

    func validatedEndpointURL() throws -> URL {
        let value = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https" else {
            if URLComponents(string: value)?.scheme?.lowercased() == "http" {
                throw FreeRepsConfigError.insecureEndpoint
            }
            throw FreeRepsConfigError.invalidEndpoint
        }
        guard components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              url.baseURL == nil else {
            throw FreeRepsConfigError.invalidEndpoint
        }
        return url
    }

    /// Earliest date to backfill from, based on `backfillMonths`.
    var backfillStartDate: Date {
        if let months = backfillMonths {
            return Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        }
        return Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!
    }

    private enum CodingKeys: String, CodingKey {
        case endpointURL
        case backfillMonths
        case rollingWindowDays

        // Legacy FreeReps connection fields.
        case host
        case port
        case useHTTPS
        case backfillYears
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let endpoint = try container.decodeIfPresent(String.self, forKey: .endpointURL) {
            endpointURL = endpoint
        } else {
            let host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
            let port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 443
            let useHTTPS = try container.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? true
            if useHTTPS, !host.isEmpty {
                endpointURL = port == 443 ? "https://\(host)/health" : "https://\(host):\(port)/health"
            } else {
                endpointURL = Self.default.endpointURL
            }
        }

        if let months = try container.decodeIfPresent(Int.self, forKey: .backfillMonths) {
            backfillMonths = months
        } else if let years = try container.decodeIfPresent(Int.self, forKey: .backfillYears) {
            backfillMonths = years * 12
        } else {
            backfillMonths = nil
        }

        rollingWindowDays = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .rollingWindowDays) ?? 7
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpointURL, forKey: .endpointURL)
        try container.encode(backfillMonths, forKey: .backfillMonths)
        try container.encode(rollingWindowDays, forKey: .rollingWindowDays)
    }

    private static let userDefaultsKey = "freerepsConfig_v1"

    static func load(defaults: UserDefaults = .standard) -> FreeRepsConfig {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(FreeRepsConfig.self, from: data),
              (try? config.validatedEndpointURL()) != nil else {
            return .default
        }
        return config
    }

    @discardableResult
    func save(defaults: UserDefaults = .standard) -> Bool {
        guard (try? validatedEndpointURL()) != nil,
              let data = try? JSONEncoder().encode(self) else {
            return false
        }
        defaults.set(data, forKey: FreeRepsConfig.userDefaultsKey)
        return true
    }
}
