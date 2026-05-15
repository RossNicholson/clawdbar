import CommonCrypto
import Foundation
import Security

struct UsageData: Sendable {
    var session5h: Double?      // 0.0–1.0
    var session5hReset: Date?
    var weekly7d: Double?       // 0.0–1.0
    var weekly7dReset: Date?
    var status: String?
}

@MainActor
final class UsageFetcher: ObservableObject {
    @Published var usage = UsageData()
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 60

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        isLoading = true
        lastError = nil
        do {
            let token = try readAccessToken()
            let result = try await fetchUsage(token: token)
            usage = result
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Credential reading

    private func readAccessToken() throws -> String {
        if let token = try? readCLIToken() { return token }
        return try readDesktopAppToken()
    }

    private func readCLIToken() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String else {
            throw FetchError.noCredentials
        }
        return token
    }

    private func readDesktopAppToken() throws -> String {
        let keychainKey = try keychainPassword(service: "Claude Safe Storage")
        let salt = Data("saltysalt".utf8)
        let aesKey = pbkdf2SHA1(password: keychainKey, salt: salt, iterations: 1003, keyLength: 16)

        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        let configData = try Data(contentsOf: configPath)

        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let tokenCacheStr = config["oauth:tokenCache"] as? String else {
            throw FetchError.noCredentials
        }

        let padCount = (4 - tokenCacheStr.count % 4) % 4
        let padded = tokenCacheStr + String(repeating: "=", count: padCount)
        guard let encrypted = Data(base64Encoded: padded), encrypted.count > 3 else {
            throw FetchError.noCredentials
        }

        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 0x20, count: 16)
        let decrypted = try aesDecrypt(key: aesKey, iv: iv, ciphertext: ciphertext)

        guard let tokenCache = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            throw FetchError.noCredentials
        }

        // Prefer the most permissive scope
        let sorted = tokenCache.sorted { a, b in
            let score: (String) -> Int = { key in
                if key.contains("claude_code") { return 2 }
                if key.contains("profile") { return 1 }
                return 0
            }
            return score(a.key) > score(b.key)
        }

        guard let entry = sorted.first?.value as? [String: Any],
              let token = entry["token"] as? String else {
            throw FetchError.noCredentials
        }
        return token
    }

    // MARK: - Crypto

    private func keychainPassword(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw FetchError.noCredentials
        }
        return key
    }

    private func pbkdf2SHA1(password: String, salt: Data, iterations: UInt32, keyLength: Int) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: keyLength)
        passwordData.withUnsafeBytes { pwdBytes in
            salt.withUnsafeBytes { saltBytes in
                derivedKey.withUnsafeMutableBytes { dkBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        dkBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return derivedKey
    }

    private func aesDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let ciphertextBytes = [UInt8](ciphertext)
        var outputBuffer = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var numDecrypted = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes, key.count,
            ivBytes,
            ciphertextBytes, ciphertext.count,
            &outputBuffer, outputBuffer.count,
            &numDecrypted
        )
        guard status == kCCSuccess else { throw FetchError.decryptionFailed }
        return Data(outputBuffer.prefix(numDecrypted))
    }

    // MARK: - API

    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }

        let headers = http.allHeaderFields as? [String: String] ?? [:]
        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var result = UsageData()
        result.session5h = headers["anthropic-ratelimit-unified-5h-utilization"].flatMap(Double.init)
        result.weekly7d = headers["anthropic-ratelimit-unified-7d-utilization"].flatMap(Double.init)
        result.session5hReset = headers["anthropic-ratelimit-unified-5h-reset"].flatMap {
            isoParser.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        result.weekly7dReset = headers["anthropic-ratelimit-unified-7d-reset"].flatMap {
            isoParser.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        result.status = headers["anthropic-ratelimit-unified-5h-status"]
        return result
    }

    // MARK: - Errors

    enum FetchError: LocalizedError {
        case noCredentials
        case badResponse
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .noCredentials:    return "No Claude credentials found"
            case .badResponse:      return "Unexpected response from Anthropic API"
            case .decryptionFailed: return "Failed to decrypt credentials"
            }
        }
    }
}

func formatTimeRemaining(until date: Date) -> String {
    let seconds = max(0, date.timeIntervalSinceNow)
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let days = hours / 24

    if days > 0 {
        let h = hours % 24
        return h > 0 ? "\(days)d \(h)h" : "\(days)d"
    } else if hours > 0 {
        let m = minutes % 60
        return m > 0 ? "\(hours)h \(m)m" : "\(hours)h"
    }
    return "\(minutes)m"
}
