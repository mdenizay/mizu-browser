import AppKit
import WebKit

/// A separate browsing identity: its own cookies and site data, history,
/// bookmarks, tabs and look.
final class Profile: ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    @Published var name: String { didSet { changed() } }
    /// SF Symbol shown for the profile.
    @Published var symbol: String { didSet { changed() } }
    @Published var color1: Int { didSet { changed() } }
    /// The gradient's second colour, or -1 for a single colour.
    @Published var color2: Int { didSet { changed() } }
    /// How strongly the colours wash over the window.
    @Published var intensity: Double { didSet { changed() } }
    var position: Int

    private(set) lazy var dataStore: WKWebsiteDataStore = isPrivate ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: id)

    init(row: ProfileRow) {
        id = UUID(uuidString: row.id) ?? UUID()
        isPrivate = false
        name = row.name
        symbol = row.symbol
        color1 = row.color1
        color2 = row.color2
        intensity = row.intensity
        position = row.position
    }

    init(name: String, symbol: String, color1: Int, color2: Int = -1, position: Int = 0, isPrivate: Bool = false) {
        id = UUID()
        self.isPrivate = isPrivate
        self.name = name
        self.symbol = symbol
        self.color1 = color1
        self.color2 = color2
        intensity = 0.22
        self.position = position
    }

    var key: String { id.uuidString }
    var accent: NSColor { NSColor(hex: color1) }

    var row: ProfileRow {
        ProfileRow(id: key, name: name, symbol: symbol, color1: color1, color2: color2, intensity: intensity, position: position)
    }

    private var saveScheduled = false

    /// Saves and announces a change, once per run loop turn: dragging in the
    /// colour field changes several values many times a second.
    private func changed() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [self] in
            saveScheduled = false
            if !isPrivate { Store.shared.save(row) }
            NotificationCenter.default.post(name: .profilesChanged, object: self)
        }
    }

    /// A throwaway profile for a private window: nothing is written to disk.
    static func makePrivate() -> Profile {
        Profile(name: L("Private"), symbol: "eyeglasses", color1: 0x5E5CE6, color2: 0x2C2C54, isPrivate: true)
    }

    static let symbols = ["person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "cart.fill", "gamecontroller.fill",
                          "hammer.fill", "leaf.fill", "heart.fill", "star.fill", "bolt.fill", "airplane", "book.fill", "music.note",
                          "camera.fill", "banknote.fill", "globe", "flask.fill"]
}

final class Profiles: ObservableObject {
    static let shared = Profiles()
    @Published private(set) var all: [Profile] = []

    private init() {
        all = Store.shared.profiles().map(Profile.init(row:))
        if all.isEmpty {
            // The two most people want; both can be renamed or removed.
            add(name: L("Personal"), symbol: "person.fill", color1: 0x0A84FF)
            add(name: L("Work"), symbol: "briefcase.fill", color1: 0xE8792B)
        }
    }

    @discardableResult
    func add(name: String, symbol: String, color1: Int, color2: Int = -1) -> Profile {
        let profile = Profile(name: name, symbol: symbol, color1: color1, color2: color2, position: (all.map(\.position).max() ?? 0) + 1)
        Store.shared.save(profile.row)
        all.append(profile)
        NotificationCenter.default.post(name: .profilesChanged, object: nil)
        return profile
    }

    func profile(_ key: String) -> Profile? {
        all.first { $0.key == key }
    }

    /// Removes a profile with its tabs, history, bookmarks and site data.
    func remove(_ profile: Profile) {
        guard all.count > 1, let index = all.firstIndex(where: { $0 === profile }) else { return }
        all.remove(at: index)
        for window in BrowserWindowController.all { window.tabs.profileRemoved(profile, fallback: all[0]) }
        Store.shared.deleteProfile(profile.key)
        // The data store can only be removed once no web view uses it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            WKWebsiteDataStore.remove(forIdentifier: profile.id) { _ in }
        }
        NotificationCenter.default.post(name: .profilesChanged, object: nil)
    }
}
