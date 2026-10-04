import Foundation
import Security

/// Sign-ins kept with a profile: a client's accounts stay with that client.
/// They live in the macOS keychain (as internet passwords, the profile's id
/// in the security domain), so they are encrypted at rest and never written
/// to Mizu's own files.
enum Vault {
    struct Login: Identifiable, Hashable {
        let host: String
        let user: String
        var id: String { host + "\n" + user }
    }

    private static func query(_ profile: Profile, host: String? = nil, user: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrSecurityDomain: "mizu." + profile.key,
        ]
        if let host { query[kSecAttrServer] = host }
        if let user { query[kSecAttrAccount] = user }
        return query
    }

    /// A site's sign-ins are shared by its subdomains' "www." form only.
    private static func normalised(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func logins(_ profile: Profile, host: String? = nil) -> [Login] {
        guard !profile.isPrivate else { return [] }
        var query = query(profile, host: host.map(normalised))
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer] as? String, let user = item[kSecAttrAccount] as? String else { return nil }
            return Login(host: host, user: user)
        }
        .sorted { ($0.host, $0.user) < ($1.host, $1.user) }
    }

    static func password(_ profile: Profile, _ login: Login) -> String? {
        var query = query(profile, host: login.host, user: login.user)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ profile: Profile, host: String, user: String, password: String) -> Bool {
        guard !profile.isPrivate, !user.isEmpty, !password.isEmpty, let data = password.data(using: .utf8) else { return false }
        let host = normalised(host)
        let query = query(profile, host: host, user: user)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Mizu: \(host) (\(profile.name))"
        item[kSecAttrProtocol] = kSecAttrProtocolHTTPS
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ profile: Profile, _ login: Login) {
        SecItemDelete(query(profile, host: login.host, user: login.user) as CFDictionary)
    }

    /// Forgets everything kept for a profile (when the profile is deleted).
    static func deleteAll(_ profile: Profile) {
        SecItemDelete(query(profile) as CFDictionary)
    }
}
